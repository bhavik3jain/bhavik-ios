import Core
import CoreData
import SwiftUI

public enum PointsTrackerModule {
    public static let accent = ModuleAccent(name: "Points", color: Color(red: 0.55, green: 0.36, blue: 0.85))

    /// The white-on-accent symbol on the hub row, the Mac sidebar tile and
    /// its Overview card.
    public static let symbolName = "star.circle.fill"

    /// Its tabs on the phone and, in the same order, the rows nested under it
    /// in the Mac sidebar. The first is where the module opens.
    public static let sections = [
        ModuleSection("accounts", title: "Accounts", systemImage: "star.circle"),
        ModuleSection("people", title: "People", systemImage: "person.2"),
    ]

    /// No SwiftData models: Points was built on Core Data from the start so
    /// a household can be shared with a partner. See `PointsModel`.
    ///
    /// `context` and `container` are the module's own store, built in
    /// `BhavikApp.init()` — re-scoped onto the standard keys here so every
    /// view below reads `@Environment(\.managedObjectContext)` and
    /// `\.pointsPersistentContainer`, exactly as Fuel does.
    ///
    /// `section` is the Mac sidebar's selection, which picks the section in
    /// place of a tab bar; leave it nil on the phone.
    @MainActor
    public static func rootView(
        context: NSManagedObjectContext,
        container: NSPersistentCloudKitContainer,
        section: Binding<String>? = nil
    ) -> some View {
        PointsRootView(section: section)
            .environment(\.managedObjectContext, context)
            .environment(\.pointsPersistentContainer, container)
    }
}
