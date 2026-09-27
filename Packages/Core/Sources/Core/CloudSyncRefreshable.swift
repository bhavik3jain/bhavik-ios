import CoreData
import SwiftUI

public extension View {
    /// Pull to refresh from iCloud, waiting on this screen's own store: the
    /// one `\.managedObjectContext` resolves to here, which each Core Data
    /// module's `rootView(context:container:)` scopes to its own container.
    ///
    /// The spinner stays up until an import has actually landed or the
    /// monitor gives up (see `CloudSyncMonitor.refresh`), so letting go of it
    /// means the screen is as fresh as iCloud could make it — not that a
    /// timer ran out. With no monitor in the environment (a preview) nothing
    /// is added, rather than a pull that pretends to do something.
    func refreshesFromCloud() -> some View {
        modifier(CloudRefreshModifier())
    }

    /// Puts a screen that doesn't scroll — an empty state, above all — in a
    /// scroll view, so an enclosing `.refreshesFromCloud()` can reach it.
    ///
    /// `.refreshable` only attaches to a scrollable container. Every tracker's
    /// "No trips" / "No guides" / "No vehicles" screen is a bare
    /// `ContentUnavailableView`, so pulling on it did nothing — on a new device
    /// or for a new partner waiting on the first record, exactly when a
    /// refresh matters most. Sized to the visible area so it stays centred
    /// the way it was.
    func scrollsForRefresh() -> some View {
        ScrollView {
            containerRelativeFrame([.horizontal, .vertical])
        }
    }
}

private struct CloudRefreshModifier: ViewModifier {
    @Environment(CloudSyncMonitor.self) private var monitor: CloudSyncMonitor?
    @Environment(\.managedObjectContext) private var context

    func body(content: Content) -> some View {
        if let monitor {
            content.refreshable {
                await monitor.refresh(storesOf: context.persistentStoreCoordinator)
            }
        } else {
            content
        }
    }
}
