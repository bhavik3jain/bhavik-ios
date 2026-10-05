import CoreData
import SwiftUI

/// Per-module Core Data context environment keys, for the modules migrating
/// off SwiftData onto `CloudSharedStore` (Trips, Fuel, Explore).
///
/// Trips got there first and claimed SwiftUI's own `\.managedObjectContext`
/// key, set once at `BhavikApp`'s `WindowGroup` level — that's the ambient
/// value every one of Trips' own views reads via `@Environment(\.managedObjectContext)`,
/// since `TripTrackerModule.rootView(context:)` re-scopes that same key to
/// Trips' own container for everything under it.
///
/// That re-scoping is exactly why a second module's *internal* views need no
/// key of their own — `FuelTrackerModule.rootView(context:)` sets
/// `\.managedObjectContext` to Fuel's container the same way, and that
/// override only reaches Fuel's own subtree. The clash is one level up: the
/// app shell (`HomeView`, `AppSettingsView`) needs its own top-level
/// `@FetchRequest`s against BOTH Trips' and Fuel's stores at once, in the same
/// view, and `\.managedObjectContext` can only carry one value there. Hence a
/// distinct key per additional module, set alongside the standard one at the
/// `WindowGroup` level in `BhavikApp.init()`. Explore, migrating next, needs
/// its own the same way.
public extension EnvironmentValues {
    /// Fuel's Core Data context, for the app shell's own top-level use
    /// (`HomeView`'s vehicle summary and peek, `AppSettingsView`'s counts).
    /// Fuel's own views never read this key directly — they read
    /// `\.managedObjectContext`, re-scoped to the same context by
    /// `FuelTrackerModule.rootView(context:)`.
    @Entry var fuelManagedObjectContext: NSManagedObjectContext?

    /// Explore's Core Data context, for the app shell's own top-level use
    /// (`HomeView`'s guide summary and peek, `AppSettingsView`'s counts).
    /// Explore's own views never read this key directly — they read
    /// `\.managedObjectContext`, re-scoped to the same context by
    /// `ExploreTrackerModule.rootView(context:)`.
    @Entry var exploreManagedObjectContext: NSManagedObjectContext?

    /// Points' Core Data context, for the app shell's own top-level use
    /// (`HomeView`'s summary and peek, `AppSettingsView`'s counts). Points'
    /// own views read `\.managedObjectContext`, re-scoped by
    /// `PointsTrackerModule.rootView(context:container:)`.
    @Entry var pointsManagedObjectContext: NSManagedObjectContext?

    /// Finance's Core Data context, for the app shell's own top-level use
    /// (`HomeView`'s net-worth line and peek, `AppSettingsView`'s counts).
    /// Finance's own views read `\.managedObjectContext`, re-scoped by
    /// `FinanceTrackerModule.rootView(context:container:)`.
    @Entry var financeManagedObjectContext: NSManagedObjectContext?

    /// TV's watch-list store — the one Core Data store in an otherwise
    /// SwiftData module, since a list is the one thing in TV two people keep
    /// together. For the app shell's own use; TV's list views read
    /// `\.managedObjectContext`, re-scoped by
    /// `TVTrackerModule.rootView(context:container:section:)`.
    @Entry var tvListManagedObjectContext: NSManagedObjectContext?
}
