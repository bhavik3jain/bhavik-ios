import Core
import CoreData
import SwiftUI

public enum FinanceTrackerModule {
    public static let accent = ModuleAccent(name: "Finance", color: Color(red: 0.11, green: 0.50, blue: 0.25))

    /// Its tabs on the phone and, in the same order, the rows nested under it
    /// in the Mac sidebar. The first is where the module opens.
    public static let sections = [
        ModuleSection("summary", title: "Summary", systemImage: "chart.line.uptrend.xyaxis"),
        ModuleSection("months", title: "Months", systemImage: "calendar"),
        ModuleSection("spending", title: "Spending", systemImage: "creditcard"),
        ModuleSection("holdings", title: "Holdings", systemImage: "building.columns"),
    ]

    /// The hub row's and peek's icon.
    public static let symbolName = "chart.line.uptrend.xyaxis.circle.fill"

    /// No SwiftData models: Finance is on Core Data from the start so a
    /// household's balance sheet can be shared with a partner. See `FinanceModel`.
    ///
    /// `context` and `container` are the module's own store, built in
    /// `BhavikApp.init()` — re-scoped onto the standard keys here so every
    /// view below reads `@Environment(\.managedObjectContext)` and
    /// `\.financePersistentContainer`, exactly as Points does.
    ///
    /// `section` is the Mac sidebar's selection, which picks the section in
    /// place of a tab bar; leave it nil on the phone.
    @MainActor
    public static func rootView(
        context: NSManagedObjectContext,
        container: NSPersistentCloudKitContainer,
        section: Binding<String>? = nil
    ) -> some View {
        FinanceRootView(section: section)
            .environment(\.managedObjectContext, context)
            .environment(\.financePersistentContainer, container)
    }
}
