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

    /// The id of the Mac's report window scene. The app declares
    /// `WindowGroup(id: FinanceTrackerModule.reportWindowID, for: FinanceReportWindowValue.self)`
    /// around `reportWindow(value:context:container:)`; Finance opens it with
    /// `openWindow(id:value:)` (see `presentsReport(_:)`).
    public static let reportWindowID = "finance-report"

    /// The Mac's report window: a contents sidebar, the web report and an
    /// inspector with the review and "Ask about <month>". `value` is the
    /// window's own and follows its stepping to another month or person while
    /// it's open. Restoration is disabled on the scene (see BhavikApp), so nil
    /// only comes from File ▸ New Report Window; it opens the month the
    /// Summary headlines.
    ///
    /// The window is a scene of its own, outside the module's root view, so
    /// it gets Finance's store here exactly as `rootView` does — a report
    /// built off another module's context would find no household.
    @MainActor
    public static func reportWindow(
        value: Binding<FinanceReportWindowValue?>,
        context: NSManagedObjectContext,
        container: NSPersistentCloudKitContainer
    ) -> some View {
        MacReportWindow(value: value)
            .environment(\.managedObjectContext, context)
            .environment(\.financePersistentContainer, container)
            .environment(\.moduleLayout, .sidebar)
            .tint(accent.color)
    }
}

/// What a Mac report window is opened with: the scope and
/// whose figures. `ownerName` nil is Everyone. Owners are named rather than
/// referenced because the value is encoded with the window and an owner
/// object can't leave the store; a name no owner has any more reads as
/// Everyone.
public struct FinanceReportWindowValue: Codable, Hashable, Sendable, Identifiable {
    public var scope: ReportScope
    public var ownerName: String?

    public init(scope: ReportScope, ownerName: String? = nil) {
        self.scope = scope
        self.ownerName = ownerName
    }

    public var id: String { scope.rawValue + "|" + (ownerName ?? "") }
}
