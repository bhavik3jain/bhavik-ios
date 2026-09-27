import Core
import CoreData
import SwiftData
import SwiftUI

public enum TripTrackerModule {
    public static let accent = ModuleAccent(name: "Trips", color: Color(red: 0.13, green: 0.52, blue: 0.93))

    /// The white-on-accent symbol on the hub row, the Mac sidebar tile and
    /// its Overview card.
    public static let symbolName = "suitcase.rolling.fill"

    /// Its tabs on the phone and, in the same order, the rows nested under it
    /// in the Mac sidebar. The first is where the module opens.
    public static let sections = [
        ModuleSection("trips", title: "Trips", systemImage: "suitcase"),
    ]

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
    ///
    /// `container` is that same store's `NSPersistentCloudKitContainer`
    /// itself — the Share button and sharing-status badges (`TripDetailView`,
    /// `TripListView`) need it to call `presentShareSheet` and
    /// `SharingStatusResolver`, which a context alone can't get them back to.
    /// See Core's `ModulePersistentContainers.swift`.
    ///
    /// `trip` and `tripSection` are the Mac sidebar's: which trip is open and
    /// on which face, with the trip list shown while `trip` is nil. Leave
    /// both nil on the phone, where the list pushes a trip itself.
    @MainActor
    public static func rootView(
        context: NSManagedObjectContext,
        container: NSPersistentCloudKitContainer,
        trip: Binding<NSManagedObjectID?>? = nil,
        tripSection: Binding<TripSection>? = nil
    ) -> some View {
        TripRootView(trip: trip, tripSection: tripSection)
            .environment(\.managedObjectContext, context)
            .environment(\.tripPersistentContainer, container)
    }

    /// The line under "Trips" on the home screen.
    public static func homeDetail(trips: [SharedTrip], asOf now: Date = .now) -> String {
        TripOverview.homeDetail(trips: trips, asOf: now)
    }

    /// The trips the Mac sidebar nests under Trips: under way and upcoming,
    /// soonest first, then the finished ones behind a "Past trips" disclosure,
    /// most recent first. `underWay` names the trips in progress, which the
    /// sidebar marks with a dot.
    public static func sidebarTrips(
        _ trips: [SharedTrip],
        asOf now: Date = .now
    ) -> (current: [SharedTrip], past: [SharedTrip], underWay: Set<NSManagedObjectID>) {
        let groups = TripGroups(trips, asOf: now)
        return (groups.inProgress + groups.upcoming, groups.finished, Set(groups.inProgress.map(\.objectID)))
    }

    /// The short figure beside Trips in the Mac sidebar: "Day 3" while a trip
    /// runs, "in 12 days" before the next one, nil with nothing ahead.
    public static func sidebarDetail(trips: [SharedTrip], asOf now: Date = .now) -> String? {
        let groups = TripGroups(trips, asOf: now)
        if let current = groups.inProgress.first, let day = current.dates.dayNumber(asOf: now) {
            return "Day \(day)"
        }
        if let next = groups.upcoming.first {
            return TripOverview.countdown(days: next.dates.daysUntilStart(asOf: now))
        }
        return nil
    }
}
