import SwiftData
import SwiftUI
import Core

public enum ExploreTrackerModule {
    public static let accent = ModuleAccent(name: "Explore", color: Color(red: 0.80, green: 0.22, blue: 0.51))

    public static var models: [any PersistentModel.Type] {
        [Guide.self, GuidePlace.self]
    }

    @MainActor
    public static func rootView() -> some View {
        ExploreRootView()
    }
}
