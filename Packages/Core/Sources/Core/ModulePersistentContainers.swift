import CoreData
import SwiftUI

/// Per-module `NSPersistentCloudKitContainer` access, for the modules that
/// moved off SwiftData onto `CloudSharedStore` (Trips first; Fuel and Explore
/// will need their own key here the same way `ModuleManagedObjectContexts.swift`
/// gave them their own `NSManagedObjectContext` key).
///
/// `\.managedObjectContext` already carries a module's *context* down to its
/// own views (see that file's doc comment for why). A Share button and
/// `SharingStatusResolver` need the *container* itself, though —
/// `ShareSheetRequest` and `SharingStatusResolver.status(for:in:)` both take
/// one — and a context alone can't get you back to it. This key closes that
/// gap the same way: set once at `BhavikApp`'s `WindowGroup` level from the
/// container `BhavikApp.init()` already builds, and re-scoped into the
/// module's own subtree by `TripTrackerModule.rootView(context:container:)`,
/// exactly parallel to how that call re-scopes `\.managedObjectContext`.
public extension EnvironmentValues {
    /// Trips' own Core Data container.
    @Entry var tripPersistentContainer: NSPersistentCloudKitContainer?

    /// Fuel's own Core Data container — same reasoning as `tripPersistentContainer`
    /// above, set from `BhavikApp.init()`'s `fuelContainer` and re-scoped into
    /// Fuel's own subtree by `FuelTrackerModule.rootView(context:container:)`.
    @Entry var fuelPersistentContainer: NSPersistentCloudKitContainer?

    /// Explore's own Core Data container — same reasoning as
    /// `tripPersistentContainer` above, set from `BhavikApp.init()`'s
    /// `exploreContainer` and re-scoped into Explore's own subtree by
    /// `ExploreTrackerModule.rootView(context:container:)`.
    @Entry var explorePersistentContainer: NSPersistentCloudKitContainer?
}
