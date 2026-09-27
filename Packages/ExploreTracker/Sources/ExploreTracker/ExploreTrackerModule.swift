import Core
import CoreData
import SwiftData
import SwiftUI

public enum ExploreTrackerModule {
    public static let accent = ModuleAccent(name: "Explore", color: Color(red: 0.80, green: 0.22, blue: 0.51))

    /// The white-on-accent symbol on the hub row, the Mac sidebar tile and
    /// its Overview card.
    public static let symbolName = "map.fill"

    /// Its tabs on the phone and, in the same order, the rows nested under it
    /// in the Mac sidebar. The first is where the module opens.
    public static let sections = [
        ModuleSection("guides", title: "Guides", systemImage: "map"),
    ]

    /// The original SwiftData models (`Guide`/`GuidePlace`), not the new
    /// Core Data ones (`SharedGuide`/`SharedGuidePlace`) — this is what keeps
    /// them registered in `AppSchema.models` in `BhavikApp.swift`, so
    /// `ExploreLegacyMigration` still has a store to read real guides from.
    /// See `SwiftDataGuide.swift`'s own doc comment: do NOT change this to
    /// the new Core Data types, and do NOT drop it from `AppSchema.models` —
    /// both are a later, human-gated step.
    public static var models: [any PersistentModel.Type] {
        [Guide.self, GuidePlace.self]
    }

    /// `context` is the module's own Core Data context — see
    /// `CloudSharedStore.makeContainer` and `BhavikApp.init()`, which builds
    /// it and passes it to this call at `HomeView.swift`'s
    /// `moduleContent(for:)`. Set on the environment here, at the top of the
    /// module's own view tree, rather than relying on the app shell having
    /// set it globally — every view below this one that reads
    /// `@Environment(\.managedObjectContext)` gets it from here.
    ///
    /// `container` is that same store's `NSPersistentCloudKitContainer`
    /// itself — the Share button and sharing-status badges (`GuideDetailView`,
    /// `GuideListView`, `AddPlaceView`) need it to call `presentShareSheet` and
    /// `SharingStatusResolver`, which a context alone can't get them back to.
    /// See Core's `ModulePersistentContainers.swift`.
    @MainActor
    public static func rootView(context: NSManagedObjectContext, container: NSPersistentCloudKitContainer) -> some View {
        ExploreRootView()
            .environment(\.managedObjectContext, context)
            .environment(\.explorePersistentContainer, container)
    }
}
